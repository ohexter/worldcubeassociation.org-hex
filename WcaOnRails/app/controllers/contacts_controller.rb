class ContactsController < ApplicationController
  def wrc
    @contact = Contact.new
  end

  def wrc_create
    @contact = Contact.new(params[:contact])
    @contact.request = request
    @contact.to_email = "wrc@worldcubeassociation.org"
    @contact.subject = "WRC Contact Form"
    maybe_send_email success_url: contact_wrc_url, fail_view: :wrc
  end

  def website
    @contact = Contact.new
  end

  def website_create
    @contact = Contact.new(params[:contact])
    @contact.request = request
    @contact.to_email = "contact@worldcubeassociation.org"
    @contact.subject = "WCA Website Comments"
    maybe_send_email success_url: contact_website_url, fail_view: :website
  end

  private def maybe_send_email(success_url: nil, fail_view: nil)
    if not @contact.valid?
      flash.now[:danger] = "Invalid fields, please correct errors below."
      render fail_view
    elsif not verify_recaptcha
      # Convert flash to a flash.now, since we're about to render, not redirect.
      flash.now[:recaptcha_error] = flash[:recaptcha_error]
      render fail_view
    elsif @contact.deliver
      flash[:success] = 'Thank you for your message. We will contact you soon!'
      redirect_to success_url
    else
      flash.now[:danger] = 'Error sending message.'
      render fail_view
    end
  end
end
