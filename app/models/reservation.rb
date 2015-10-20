class Reservation < ActiveRecord::Base
  belongs_to :user
  has_many :passengers, inverse_of: :reservation, autosave: true, dependent: :destroy
  has_many :flights, inverse_of: :reservation, autosave: true, dependent: :destroy
  has_many :checkins, through: :flights, dependent: :destroy
  accepts_nested_attributes_for :user

  before_validation :retrieve_reservation, on: :create
  before_create :create_passengers
  before_create :create_flights
  before_save :upcase_confirmation_number
  after_create :schedule_checkins
  after_commit :send_new_reservation_email, on: :create

  validates_associated :passengers
  validates :confirmation_number, length: { is: 6 }
  validates :confirmation_number,
            :first_name,
            :last_name,
            :payload,
            presence: true

  scope :ordered_by_departure_time, -> { includes(:flights).order("flights.departure_time") }

  def departure_flights
    flights.departure.order(:departure_time)
  end

  def return_flights
    flights.return.order(:departure_time)
  end

  def time
    departure_flights.any? ? departure_flights.first.departure_time : nil
  end

  def international?
    payload['body'] ? payload['body']['isInternationalPNR'] == 'true' : false
  end

  def checkins_completed?
    checkins.count == checkins.completed.count
  end

  private

  def upcase_confirmation_number
    self.confirmation_number = self.confirmation_number.upcase
  end

  def retrieve_reservation
    retrieved_reservation = southwest_reservation

    if retrieved_reservation.error?
      invalidate_reservation(retrieved_reservation)
      return false
    end

    if retrieved_reservation.international?
      errors[:base] << "Unfortunately, do to uncontrolled limitations of the checkin process, international flights are not yet supported."
    end

    self.payload = retrieved_reservation.to_hash
    self.arrival_city_name = retrieved_reservation.arrival_city_name
  end

  def create_passengers
    passengers_attributes = PassengersParser.new(southwest_reservation.body).passengers

    passengers_attributes.each do |passenger_attributes|
      passengers.new(passenger_attributes)
    end
  end

  def create_flights
    flights_attributes = FlightsParser.new(southwest_reservation.body).flights

    flights_attributes.each do |flight_attributes|
      flights.new(flight_attributes)
    end
  end

  def southwest_reservation
    @southwest_reservation ||= Southwest::Reservation.retrieve_reservation(
      last_name: last_name,
      first_name: first_name,
      record_locator: confirmation_number
    )
  end

  def schedule_checkins
    flights.where(position: 1).where("departure_time > ?", Time.zone.now).each do |flight|
      flight.schedule_checkin
    end
  end

  def invalidate_reservation(response)
    if response.entered_incorrectly?
      errors.add(:confirmation_number, 'verify your confirmation number is entered correctly')
      errors.add(:first_name, 'verify your first name is entered correctly')
      errors.add(:last_name, 'verify your last name is entered correctly')
    elsif response.cancelled?
      errors[:base] << "Your reservation has been cancelled"
    else
      errors[:base] << response.error
    end
  end

  def send_new_reservation_email
    ReservationMailer.new_reservation(self).deliver_later
  end
end
